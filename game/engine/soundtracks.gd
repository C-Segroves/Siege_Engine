class_name Soundtracks
extends RefCounted
## Music the user brought in: CD-audio tracks imported with a disc (<pack>/audio/cd/) and ripped
## soundtrack folders (<packs>/_soundtracks/<pack>/), plus each pack's rendered game music.
## Each source has a tracks.json; this merges them into one list per game.


## pack -> {"name": String, "tracks": [{file(abs path), title, seconds, cd_track?, source}]}
static func all() -> Dictionary:
	var out := {}
	if Assets.data_root == "":
		return out
	var store := Assets.data_root.path_join("_soundtracks")
	if DirAccess.dir_exists_absolute(store):   # absent until a soundtrack folder is imported
		for p in DirAccess.get_directories_at(store):
			_add(out, p, store.path_join(p), "soundtrack")
	for p in Assets.installed_packs():
		_add(out, p, Assets.path("audio/cd", p), "disc")
		_add_rendered(out, p)
	return out


static func _add(out: Dictionary, pack: String, dir: String, source: String) -> void:
	var f := FileAccess.open(dir.path_join("tracks.json"), FileAccess.READ)
	if f == null:
		return
	var j = JSON.parse_string(f.get_as_text())
	if not j is Dictionary:
		return
	var e: Dictionary = out.get(pack, {"name": j.get("name", Packs.pack_name(pack)), "tracks": []})
	for t in j.get("tracks", []):
		var path := dir.path_join(String(t.get("file", "")))
		if not FileAccess.file_exists(path):
			continue
		var title := String(t.get("name", t.get("title", "")))
		if title == "":
			title = "Track %02d" % int(t.get("cd_track", t.get("album_track", e.tracks.size() + 1)))
		e.tracks.append({"file": path, "title": title, "seconds": float(t.get("seconds", 0.0)),
			"cd_track": t.get("cd_track"), "source": source})
	out[pack] = e


## Music from the game's own data: the FM renders for the chosen music device (music.json) and streamed
## music files in <pack>/audio/music/.
static func _add_rendered(out: Dictionary, pack: String) -> void:
	var dir := Assets.path("audio/music", pack)
	if not DirAccess.dir_exists_absolute(dir):
		return
	var e: Dictionary = out.get(pack, {"name": Packs.pack_name(pack), "tracks": []})
	var names: Array = MusicLibrary.catalog(pack).get("tracks", {}).keys()
	for fn in DirAccess.get_files_at(dir):
		if fn.get_extension() in MusicLibrary.STREAM_EXTENSIONS and not names.has(fn.get_basename()):
			names.append(fn.get_basename())
	for n in names:
		var path := MusicLibrary.track_path(String(n), pack)
		if path != "":
			e.tracks.append({"file": path, "title": String(n), "seconds": 0.0, "source": "game"})
	if not e.tracks.is_empty():
		out[pack] = e


## CD track for a game's request (handles script quirks such as Starsiege's track 14 -> 11).
static func cd_track_file(pack: String, track: int) -> String:
	for dir: String in [Assets.data_root.path_join("_soundtracks").path_join(pack), Assets.path("audio/cd", pack)]:
		var f := FileAccess.open(dir.path_join("tracks.json"), FileAccess.READ)
		if f == null:
			continue
		var j = JSON.parse_string(f.get_as_text())
		if not j is Dictionary:
			continue
		var t := int(j.get("aliases", {}).get(str(track), track))
		var p := dir.path_join("track_%02d.ogg" % t)
		if FileAccess.file_exists(p):
			return p
	return ""
