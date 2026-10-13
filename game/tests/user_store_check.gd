extends Node
## The test store (UserStore): a test process never touches the player's files.
##   1 a test scene runs in its own store (user://test_store/<pid>), seeded with the player's settings files
##   2 every holder writes there: campaign saves, extraction profiles, settings.json, input.json, content.json, the
##     legacy careers file; SavedCampaignGuard keeps its API and changes nothing more
##   3 the player's files (user://saves recursively, settings / input / content, the careers files) are
##     byte-identical (md5) before and after
##   godot --headless --audio-driver Dummy --path game res://tests/user_store_check.tscn

const SavedCampaignGuard := preload("res://tests/saved_campaign_guard.gd")
const PLAYER_FILES := ["settings.json", "input.json", "content.json", "es1_careers.json", "es1_careers.moved.json"]

var _failures := 0


func _ready() -> void:
	var before := make_player_hashes()
	print("1 the store:")
	_expect(UserStore.is_test_store() and UserStore.root() == UserStore.make_process_dir(), "a test scene runs in its own store (%s)" % UserStore.root())
	_expect(SaveGames.DIR.begins_with(UserStore.root()) and SaveGames.PROFILE_DIR.begins_with(UserStore.root())
		and Assets.SETTINGS_FILE.begins_with(UserStore.root()) and SiegeInput.SETTINGS_FILE.begins_with(UserStore.root())
		and Packs.CONTENT_FILE.begins_with(UserStore.root()) and ShellCareers.LEGACY_FILE.begins_with(UserStore.root()),
		"every holder's path is in it")
	_expect(not FileAccess.file_exists(UserStore.REAL_ROOT.path_join("settings.json")) or FileAccess.file_exists(Assets.SETTINGS_FILE),
		"the player's settings were copied in")
	print("2 writes:")
	_write_everything()
	var guard := SavedCampaignGuard.new()
	guard.back_up()
	_write_everything()
	guard.restore()
	_expect(UserStore.is_test_store(), "the guard keeps the process's store")
	_expect(FileAccess.file_exists(SaveGames.make_path("qa_user_store")), "the test save is in the test store")
	print("3 the player's files:")
	var after := make_player_hashes()
	var changed := before.keys().filter(func(k: String) -> bool: return before[k] != after.get(k, ""))
	changed.append_array(after.keys().filter(func(k: String) -> bool: return not before.has(k)))
	_expect(changed.is_empty(), "byte-identical (%d files; changed: %s)" % [before.size(), changed])
	print("user_store_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _write_everything() -> void:
	SaveGames.write("qa_user_store", {"meta": {"kind": SaveGames.KIND_MANUAL}})
	SaveGames.write_profile("extraction_qa_user_store", {"version": 2, "money": 1})
	Assets.settings["qa_user_store"] = true
	Assets.save_settings()
	SiegeInput.save_bindings()
	_write(Packs.CONTENT_FILE, "{}")
	_write(ShellCareers.LEGACY_FILE, "{}")


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## {path: md5} of the player's own files (never the test stores).
static func make_player_hashes() -> Dictionary:
	var out := {}
	for f in PLAYER_FILES:
		var path := UserStore.REAL_ROOT.path_join(f)
		if FileAccess.file_exists(path):
			out[path] = FileAccess.get_md5(path)
	_hash_tree(UserStore.REAL_ROOT.path_join("saves"), out)
	return out


static func _hash_tree(dir: String, out: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		out[dir.path_join(f)] = FileAccess.get_md5(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_hash_tree(dir.path_join(d), out)
