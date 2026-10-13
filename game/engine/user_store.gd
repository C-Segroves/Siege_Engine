class_name UserStore
extends RefCounted
## Where the player's own files live: the save store (SaveGames: user://saves, its profiles folder), the settings
## (Assets settings.json, SiegeInput input.json, Packs content.json) and the Earthsiege careers of earlier versions
## (ShellCareers). Every holder asks path() each time, so one switch redirects them all.
##
## A **test store** keeps tests away from the player's files (several test processes may run at once): running a
## scene under TEST_SCENES (every headless check, shot and e2e driver), the command line user arg TEST_STORE_ARG
## (`-- --test-store` or `-- --test-store=<dir>`), the environment variable TEST_STORE_ENV, or apply_test_store()
## (SavedCampaignGuard.back_up) puts everything under its own folder, user://test_store/<process id> by default
## (Assets deletes that one when the process ends). The settings files are copied in once, so a test sees the player's
## data folder and options but never writes them; clear_test_store() deletes the folder.

const REAL_ROOT := "user://"
const TEST_ROOT := "user://test_store"
const TEST_STORE_ARG := "--test-store"
const TEST_STORE_ENV := "SIEGE_TEST_STORE"
## A process started on a scene in this folder is a test: it always gets a test store.
const TEST_SCENES := "res://tests/"
## Files copied from the real store into a new test store (read-only use of the player's setup).
const COPIED_FILES := ["settings.json", "input.json", "content.json"]

static var _root := _make_initial_root()


## `rel` ("saves", "settings.json" ...) in the current store.
static func path(rel: String) -> String:
	return _root.path_join(rel)


static func is_test_store() -> bool:
	return _root != REAL_ROOT


## The current store's folder ("user://" for the player's own).
static func root() -> String:
	return _root


## Switches to a test store at `dir` ("" = TEST_ROOT/<process id>), seeded with the player's settings files.
static func apply_test_store(dir := "") -> void:
	var target := dir if dir != "" else make_process_dir()
	if _root == target:
		return
	_seed(target)
	_root = target


## Deletes the test store and goes back to the player's own (nothing when no test store is in use).
static func clear_test_store() -> void:
	if not is_test_store():
		return
	_remove_tree(ProjectSettings.globalize_path(_root))
	_root = REAL_ROOT


static func make_process_dir() -> String:
	return TEST_ROOT.path_join(str(OS.get_process_id()))


## The store the process starts with: a test store when the command line or the environment asks for one.
static func _make_initial_root() -> String:
	var dir := _make_requested_test_dir()
	if dir == "":
		return REAL_ROOT
	_seed(dir)
	return dir


## The test store folder of TEST_STORE_ARG, TEST_STORE_ENV or a test scene ("" = none asked for). A folder named
## explicitly wins over a test scene's default, so a sandbox run (tools/sandbox_iso_test.py) can hand a test scene a
## prepared store.
static func _make_requested_test_dir() -> String:
	for a in OS.get_cmdline_user_args():
		if a == TEST_STORE_ARG or a.begins_with(TEST_STORE_ARG + "="):
			return a.get_slice("=", 1) if a.contains("=") else make_process_dir()
	var env := OS.get_environment(TEST_STORE_ENV)
	if env != "":
		return env if env.begins_with("user://") or env.is_absolute_path() else make_process_dir()
	if Array(OS.get_cmdline_args()).any(func(a: String) -> bool: return a.begins_with(TEST_SCENES)):
		return make_process_dir()
	return ""


## Creates test store `dir` with copies of the player's settings files (never overwriting what it has).
static func _seed(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for f in COPIED_FILES:
		var from := REAL_ROOT.path_join(f)
		if FileAccess.file_exists(from) and not FileAccess.file_exists(dir.path_join(f)):
			DirAccess.copy_absolute(ProjectSettings.globalize_path(from), ProjectSettings.globalize_path(dir.path_join(f)))


static func _remove_tree(abs_dir: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	for d in DirAccess.get_directories_at(abs_dir):
		_remove_tree(abs_dir.path_join(d))
	for f in DirAccess.get_files_at(abs_dir):
		DirAccess.remove_absolute(abs_dir.path_join(f))
	DirAccess.remove_absolute(abs_dir)
