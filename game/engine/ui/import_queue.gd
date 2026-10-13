class_name ImportQueue
extends Node
## Disc and soundtrack imports for the library, one at a time through DiscImporter. Discs of one
## multi-disc game are grouped and imported together. Lives on the library router so an import
## keeps running while the player browses other library screens.

signal status_changed(text: String)
## 0..1 while an import runs; -1 when none runs.
signal progress_changed(fraction: float)
signal import_finished(ok: bool, pack: String)

const DISC_EXTENSIONS := ["iso", "cue", "bin"]
const IDLE := -1.0

var _importer: DiscImporter
var _queue: Array = []        # groups waiting: {info, isos}
var _busy := false


func _ready() -> void:
	_importer = DiscImporter.new()
	add_child(_importer)
	_importer.progress.connect(_on_progress)
	_importer.finished.connect(_on_finished)


func is_busy() -> bool:
	return _busy


static func is_available() -> bool:
	return not WebPlatform.is_active() and DiscImporter.available()


## The disc images among dropped / picked files.
static func filter_disc_images(files: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for f in files:
		if f.get_extension().to_lower() in DISC_EXTENSIONS:
			out.append(f)
	return out


## Identifies the discs, groups them by game and queues the groups.
func enqueue_discs(paths: PackedStringArray) -> void:
	var groups := {}
	for p in paths:
		var info := DiscImporter.identify(p)
		if info.has("error"):
			status_changed.emit("%s: %s" % [p.get_file(), info.error])
			continue
		var key: String = info.get("pack", "?")
		if not groups.has(key):
			groups[key] = {"info": info, "isos": PackedStringArray()}
		groups[key].isos.append(p)
	for k in groups:
		_warn_missing_discs(groups[k], k)
		_queue.append(groups[k])
	_start_next()


## Deletes a pack's imported data (never the original disc) and reloads the catalog.
static func remove_pack(pack: String) -> void:
	_delete_dir(Assets.data_root.path_join(pack))
	Assets.refresh()
	Packs.reload()


static func _delete_dir(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_delete_dir(path.path_join(d))
	DirAccess.remove_absolute(path)


func start_soundtracks(folder: String) -> void:
	_busy = true
	progress_changed.emit(0.0)
	status_changed.emit("Adding soundtracks from %s ..." % folder)
	_importer.start_soundtracks(PackedStringArray([folder]))


func _warn_missing_discs(group: Dictionary, key: String) -> void:
	var need := int(group.info.get("discs", 1))
	if group.isos.size() < need:
		status_changed.emit("%s has %d discs - importing the %d you selected (some content may be missing)." % [
			group.info.get("name", key), need, group.isos.size()])


func _start_next() -> void:
	if _queue.is_empty() or _busy:
		return
	var g: Dictionary = _queue.pop_front()
	_busy = true
	progress_changed.emit(0.0)
	status_changed.emit("Importing %s ..." % g.info.get("name", g.info.get("pack", "")))
	_importer.start(g.isos)


func _on_progress(fraction: float, message: String) -> void:
	if fraction >= 0.0:
		progress_changed.emit(fraction)
	if message != "":
		status_changed.emit(message)


func _on_finished(ok: bool, pack: String, message: String) -> void:
	_busy = false
	progress_changed.emit(IDLE)
	import_finished.emit(ok, pack)
	status_changed.emit("%s imported." % Packs.pack_name(pack) if ok else message)
	_start_next()
