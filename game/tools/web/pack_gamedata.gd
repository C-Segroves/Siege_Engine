extends SceneTree
## Packs imported game data for the browser build: one .pck per content pack plus a packs.json manifest that
## the page shell (game/web/siege_shell.html) offers to the player. Every file of <data>/<pack>/ lands at
## res://gamedata/<pack>/... inside its .pck (WebPlatform.DATA_ROOT), stored as raw files, so Assets reads
## them exactly like the desktop gamedata folder.
##
##   godot --headless --audio-driver Dummy --path game --script res://tools/web/pack_gamedata.gd -- \
##         --data=<gamedata dir> --out=<dir> [--packs=es1,bd | --packs=all]
##
## Exit code 0 on success, 1 on bad arguments or a write failure. Used by deploy/siege-update.sh.

const MANIFEST_FILE := "packs.json"
const MANIFEST_FORMAT := 1
const TARGET_ROOT := "res://gamedata"
const ALL_PACKS := "all"
## Pack folders that are stores rather than games carry their display name here.
const STORE_NAMES := {"_soundtracks": "Soundtracks (ripped music)"}


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	if not args.has("data") or not args.has("out"):
		printerr("usage: -- --data=<gamedata dir> --out=<dir> [--packs=es1,bd|all]")
		quit(1)
		return
	quit(0 if _pack_all(args) else 1)


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	for a in argv:
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1]
	return out


func _pack_all(args: Dictionary) -> bool:
	var data_dir: String = args.data
	var out_dir: String = args.out
	DirAccess.make_dir_recursive_absolute(out_dir)
	var entries := []
	for pack in _make_pack_list(data_dir, str(args.get("packs", ALL_PACKS))):
		var entry := _pack_one(data_dir.path_join(pack), pack, out_dir)
		if entry.is_empty():
			return false
		entries.append(entry)
	return _write_manifest(out_dir, entries)


## The pack folders to publish: every imported pack, or the comma-separated `wanted` ones that exist.
func _make_pack_list(data_dir: String, wanted: String) -> PackedStringArray:
	var present := PackedStringArray()
	for d in DirAccess.get_directories_at(data_dir):
		if not d.contains("."):          # "<pack>.old-<pid>" folders of an import in progress
			present.append(d)
	if wanted == ALL_PACKS:
		return present
	var out := PackedStringArray()
	for pack in wanted.split(",", false):
		pack = pack.strip_edges()
		if pack in present:
			out.append(pack)
		else:
			printerr("pack_gamedata: %s is not imported in %s - skipped" % [pack, data_dir])
	return out


## Writes <out>/<pack>.pck; returns its manifest entry ({} on failure).
func _pack_one(src_dir: String, pack: String, out_dir: String) -> Dictionary:
	var pck_path := out_dir.path_join(pack + ".pck")
	var packer := PCKPacker.new()
	if packer.pck_start(pck_path) != OK:
		printerr("pack_gamedata: cannot write " + pck_path)
		return {}
	var files := _make_file_list(src_dir, "")
	for rel in files:
		packer.add_file(TARGET_ROOT.path_join(pack).path_join(rel), src_dir.path_join(rel))
	if packer.flush() != OK:
		printerr("pack_gamedata: writing %s failed" % pck_path)
		return {}
	var size := _file_size(pck_path)
	print("pack_gamedata: %s  %d files  %.1f MB" % [pck_path, files.size(), size / 1048576.0])
	return {"id": pack, "name": _make_pack_name(src_dir, pack), "file": pck_path.get_file(), "size": size,
		"files": files.size(), "sha256": FileAccess.get_sha256(pck_path)}


## Every file below `dir` as a path relative to the pack folder, sorted so builds are reproducible.
func _make_file_list(root: String, rel: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := root.path_join(rel)
	for f in DirAccess.get_files_at(dir):
		out.append(rel.path_join(f) if rel != "" else f)
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_make_file_list(root, rel.path_join(d) if rel != "" else d))
	out.sort()
	return out


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f else 0


## The pack's display name from its pack.json (written by the importer), else the folder name.
func _make_pack_name(src_dir: String, pack: String) -> String:
	if STORE_NAMES.has(pack):
		return STORE_NAMES[pack]
	var meta = JSON.parse_string(FileAccess.get_file_as_string(src_dir.path_join("pack.json")))
	if meta is Dictionary and meta.has("name"):
		return str(meta.name)
	return pack


func _write_manifest(out_dir: String, entries: Array) -> bool:
	var f := FileAccess.open(out_dir.path_join(MANIFEST_FILE), FileAccess.WRITE)
	if f == null:
		printerr("pack_gamedata: cannot write the manifest in " + out_dir)
		return false
	f.store_string(JSON.stringify({"format": MANIFEST_FORMAT, "packs": entries}, " "))
	return true
