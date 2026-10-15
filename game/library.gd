class_name Library
extends ScreenRouter
## App front door (res://library.tscn): import game discs, choose what each game contributes,
## soundtracks, and start co-op / arena games or a game's original experience. Pages are scripts
## in engine/ui/screens/ (library_home, jukebox, options).
## Automation: --page=home|options|versions|jukebox:<pack> [--shot=<png>].

const SCREENS := {
	"home": "res://engine/ui/screens/library_home.gd",
	"jukebox": "res://engine/ui/screens/jukebox_screen.gd",
	"options": "res://engine/ui/screens/options_screen.gd",
	"versions": "res://engine/ui/screens/versions_screen.gd",
}
const LAUNCHER_SCENE := "res://launcher.tscn"
const SELF_SCENE := "res://library.tscn"

var imports: ImportQueue


func _ready() -> void:
	super()
	UiScale.apply(get_tree().root)
	imports = ImportQueue.new()
	add_child(imports)
	get_window().files_dropped.connect(_on_files_dropped)
	_open_first_screen()


func make_screen_paths() -> Dictionary:
	return SCREENS


## Opens the launcher in `mode`: its host page ("arena" / "coop") or a campaign page ("continue" /
## "new_campaign" / "load", Launcher.CAMPAIGN_START_MODES).
func open_launcher(mode: String) -> void:
	Session.front_end = SELF_SCENE
	var launcher: Node = load(LAUNCHER_SCENE).instantiate()
	launcher.set_meta("start_mode", mode)
	var tree := get_tree()
	tree.root.add_child(launcher)
	tree.current_scene = launcher
	queue_free()


func _on_files_dropped(files: PackedStringArray) -> void:
	var discs := ImportQueue.filter_disc_images(files)
	if not discs.is_empty():
		imports.enqueue_discs(discs)


## Back with no screen remembered: the home page.
func back_from_root() -> void:
	if current_name != "home":
		go_root("home")


func _open_first_screen() -> void:
	var parts := arg_value("page").split(":")
	match parts[0]:
		"options":
			go("options", {"home": "home"})
		"versions":
			go("versions")
		"jukebox":
			go("jukebox", {"pack": parts[1] if parts.size() > 1 else ""})
		_:
			go("home")
	if Session.front_end_status != "" and current != null:
		current.set_status(Session.front_end_status)   # e.g. "The host left the match." from the launcher
	Session.front_end_status = ""
	var shot := arg_value("shot")
	if shot != "":
		save_shot_and_quit(shot)
