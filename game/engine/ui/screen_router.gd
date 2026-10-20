class_name ScreenRouter
extends Control
## Shows one RoutedScreen at a time (library, launcher). Subclasses list their screens in
## `make_screen_paths()` (name -> script path). One navigation stack per router, so Back (and menu_back / pad B)
## always returns to the screen the player came from:
##   go(name, args)        opens a screen, remembering the current one
##   back(extra_args)      reopens the remembered screen (its own args plus `extra_args`); with nothing remembered
##                         the router decides (back_from_root: the launcher's front end, the library's home)
##   replace(name, args)   opens a screen in place of the current one (a page refreshing itself, a flow step that
##                         must not be returned to)
##   go_root(name, args)   forgets the stack and opens a screen (the main menu)
## `context` holds what screens share (e.g. the Herc picked in the armory).

const APP_TITLE := "SIEGE ENGINE"

var current: RoutedScreen
var current_name := ""
var previous_name := ""
var context := {}
var _current_args := {}
var _history: Array = []        # [[screen name, args], ...] of the screens Back returns to


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)   # also when created in code inside a tree
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	AudioSettings.apply_saved()


## Application name on every screen's title bar.
func make_app_title() -> String:
	return APP_TITLE


## name -> path of a RoutedScreen script.
func make_screen_paths() -> Dictionary:
	return {}


## Opens screen `screen_name` with `args`; Back returns to the current one.
func go(screen_name: String, args := {}) -> RoutedScreen:
	if current != null and current_name != "":
		_history.append([current_name, _current_args])
	return _open(screen_name, args)


## Opens screen `screen_name` in place of the current one (Back skips it).
func replace(screen_name: String, args := {}) -> RoutedScreen:
	return _open(screen_name, args)


## Forgets every remembered screen and opens `screen_name` (the root of the router's menus).
func go_root(screen_name: String, args := {}) -> RoutedScreen:
	_history.clear()
	return _open(screen_name, args)


## Back to the screen shown before this one, with its own args plus `extra_args`; the router's root decides when
## there is none (back_from_root).
func back(extra_args := {}) -> void:
	if _history.is_empty():
		back_from_root()
		return
	var entry: Array = _history.pop_back()
	_open(str(entry[0]), (entry[1] as Dictionary).merged(extra_args, true))


## The names of the remembered screens, oldest first (tests, the menu map).
func make_history_names() -> Array:
	return _history.map(func(e: Array) -> String: return str(e[0]))


## Back with nothing remembered: subclasses go to their home screen or leave the router.
func back_from_root() -> void:
	pass


func _open(screen_name: String, args: Dictionary) -> RoutedScreen:
	var path: String = make_screen_paths().get(screen_name, "")
	var script: GDScript = load(path) if path != "" else null
	if script == null:
		push_error("ScreenRouter: unknown screen '%s'" % screen_name)
		return current
	if current != null:
		remove_child(current)
		current.queue_free()
	previous_name = current_name
	current_name = screen_name
	_current_args = args.duplicate()
	current = script.new()
	current.router = self
	add_child(current)
	current.open(args)
	return current


## Back to the screen shown before this one (back); `fallback` is ignored (kept for older callers).
func go_back(_fallback := "") -> void:
	back()


## Makes `scene_root` the current scene in place of this router (which is freed).
func replace_with(scene_root: Node) -> void:
	replace_current_scene(get_tree(), scene_root, self)


## Adds `scene_root` under the tree root as the current scene and frees `old` (the scene it replaces).
static func replace_current_scene(tree: SceneTree, scene_root: Node, old: Node) -> void:
	tree.root.add_child(scene_root)
	tree.current_scene = scene_root
	old.queue_free()


## Waits `delay` seconds, saves a screenshot of the window to `path` and quits (automation).
func save_shot_and_quit(path: String, delay := 2.0) -> void:
	await get_tree().create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


## Arguments tests set instead of passing them on the command line: name -> value.
static var arg_overrides := {}


## Value of command-line user argument `--name=value` ("" when absent); arg_overrides wins.
static func arg_value(name: String) -> String:
	if arg_overrides.has(name):
		return str(arg_overrides[name])
	var prefix := "--%s=" % name
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""
