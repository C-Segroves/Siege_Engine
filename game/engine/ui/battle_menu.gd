class_name BattleMenu
extends ScreenRouter
## The in-battle menu, the same in every game and mode (menu_pause: Esc / pad Start): Resume,
## Options (the app's options screen), Abort mission / Leave match and Quit to main menu, both asked
## through a ConfirmDialog. It sits on its own CanvasLayer that keeps processing while the tree is
## paused; what pausing and leaving mean is decided by the battle (games/es1/battle/battle_exit.gd),
## which passes its choices in `actions`:
##   {"page": subtitle, "note": paragraph, "leave_text": button, "leave_question": confirm text,
##    "on_resume": Callable, "on_leave": Callable, "on_quit": Callable}
##   BattleMenu.open_over(parent, actions) -> BattleMenu     close() removes it again

const SCREENS := {
	"pause": "res://engine/ui/screens/pause_screen.gd",
	"options": "res://engine/ui/screens/options_screen.gd",
}
## Above the battle's HUD and cockpit layers.
const LAYER := 90

var actions := {}


## Builds the menu on a new CanvasLayer under `parent` and opens its pause page.
static func open_over(parent: Node, p_actions: Dictionary) -> BattleMenu:
	var layer := CanvasLayer.new()
	layer.name = "BattleMenuLayer"
	layer.layer = LAYER
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var menu := BattleMenu.new()
	menu.actions = p_actions
	layer.add_child(menu)
	parent.add_child(layer)
	return menu


func _ready() -> void:
	super()
	go("pause")


func make_screen_paths() -> Dictionary:
	return SCREENS


## Removes the menu and its layer.
func close() -> void:
	get_parent().queue_free()


## Runs one of the battle's choices (`key` of `actions`), if it gave one.
func run_action(key: String) -> void:
	var action: Variant = actions.get(key)
	if action is Callable and (action as Callable).is_valid():
		(action as Callable).call()
	else:
		push_error("BattleMenu: no action '%s'" % key)
