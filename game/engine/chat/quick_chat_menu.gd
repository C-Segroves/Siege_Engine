class_name QuickChatMenu
extends PanelContainer
## The quick-chat menu (chat_quick: K / pad Share): the categories of QuickChat, then a category's lines; the
## focus moves with ui_up / ui_down (d-pad, left stick, arrows), ui_accept picks, chat_cancel goes back a level
## (ChatPanel). Built from the shared widgets in the ModalPanel style.

signal picked(item: Dictionary)

var menu: Array = []
## The open category (-1: the category list).
var category := -1
var _box: VBoxContainer


func _init(p_menu: Array) -> void:
	menu = p_menu
	theme_type_variation = "ModalPanel"
	_box = VBoxContainer.new()
	add_child(_box)


func _ready() -> void:
	show_categories()


func show_categories() -> void:
	category = -1
	_rebuild("Quick chat", menu.map(func(c: Dictionary) -> String: return "%s ..." % str(c.get("name", ""))),
		func(i: int) -> void: show_category(i))


func show_category(i: int) -> void:
	category = i
	var items: Array = menu[i].get("items", [])
	_rebuild(str(menu[i].get("name", "")), items.map(func(it: Dictionary) -> String: return make_item_text(it)),
		func(k: int) -> void: picked.emit(items[k]))


## Back to the category list; false when it already shows (the menu should close).
func go_back() -> bool:
	if category < 0:
		return false
	show_categories()
	return true


## "Attack!  (team)".
static func make_item_text(item: Dictionary) -> String:
	return "%s%s" % [str(item.get("label", item.get("text", ""))), "  (team)" if bool(item.get("team", false)) else ""]


func _rebuild(title: String, texts: Array, on_pick: Callable) -> void:
	for c in _box.get_children():
		c.queue_free()
	_box.add_child(Widgets.label(title, "SectionLabel"))
	var first: Button = null
	for i in texts.size():
		var b := Widgets.small_button(str(texts[i]), on_pick.bind(i))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_FILL
		_box.add_child(b)
		if first == null:
			first = b
	if first != null:
		first.call_deferred("grab_focus")
