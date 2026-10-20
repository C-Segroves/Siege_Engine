class_name SquadList
extends VBoxContainer
## Everybody who is not on a carousel card, as a compact list (docs/design/lobby_loadout_economy.md section 5.3): one Tree
## with a row per pilot (name, class, ready state, ping) grouped by team, a filter box and the Tree's own type-ahead
## search. A Tree draws only the rows in view and makes no node per row, so 64 players cost no widgets. Rebuilt only
## when the rows change; the selection stays.
##   refresh(rows)       rows: LobbyModel.make_list_rows
##   row_count()         pilots and members listed (not groups)

const COLUMNS := ["Pilot", "Class", "State", "Ping"]
const COLUMN_RATIOS := [4.0, 3.0, 2.0, 1.5]
const COLUMN_MIN_WIDTH := [80, 70, 70, 50]
const NAME_COLUMN := 0
const MIN_LIST_HEIGHT := 140.0
const READY_TEXT := "READY"
const NOT_READY_TEXT := "not ready"
const FILTER_PLACEHOLDER := "filter"

var tree: Tree
var filter: LineEdit
var _title: Label
var _rows: Array = []
var _shown_key := ""


func _init() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var head := HBoxContainer.new()
	_title = Widgets.section("Others")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	filter = Widgets.line_edit("", FILTER_PLACEHOLDER)
	filter.custom_minimum_size = Vector2(Widgets.metric("label_width"), 0)
	filter.clear_button_enabled = true
	filter.text_changed.connect(func(_t: String) -> void: _rebuild())
	head.add_child(filter)
	add_child(head)
	tree = Tree.new()
	tree.columns = COLUMNS.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.allow_search = true
	tree.select_mode = Tree.SELECT_ROW
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.custom_minimum_size = Vector2(0, MIN_LIST_HEIGHT)
	for c in COLUMNS.size():
		tree.set_column_title(c, COLUMNS[c])
		tree.set_column_expand(c, true)
		tree.set_column_expand_ratio(c, COLUMN_RATIOS[c])
		tree.set_column_custom_minimum_width(c, COLUMN_MIN_WIDTH[c])
		tree.set_column_clip_content(c, true)
	add_child(tree)


## Shows `rows`; nothing is rebuilt when they are the same as before.
func refresh(rows: Array) -> void:
	var key := LobbyModel.make_rows_key(rows) + "|" + filter.text
	_rows = rows
	_title.text = "Others (%d)" % rows.size()
	visible = not rows.is_empty()
	if key == _shown_key:
		return
	_rebuild()


func row_count() -> int:
	return _count_rows()


func _rebuild() -> void:
	_shown_key = LobbyModel.make_rows_key(_rows) + "|" + filter.text
	var selected_key := _selected_key()
	tree.clear()
	var root := tree.create_item()
	var groups := {}
	var needle := filter.text.strip_edges().to_lower()
	for row in _rows:
		if needle != "" and not str(row.name).to_lower().contains(needle):
			continue
		var group: TreeItem = groups.get(str(row.team_name))
		if group == null:
			group = _add_group(root, str(row.team_name))
			groups[str(row.team_name)] = group
		_add_row(group, row, selected_key)
	if tree.get_selected() != null:
		tree.scroll_to_item(tree.get_selected())


func _add_group(root: TreeItem, group_name: String) -> TreeItem:
	var item := tree.create_item(root)
	item.set_text(NAME_COLUMN, group_name)
	item.set_selectable(NAME_COLUMN, false)
	for c in range(1, COLUMNS.size()):
		item.set_selectable(c, false)
	return item


func _add_row(group: TreeItem, row: Dictionary, selected_key: String) -> void:
	var item := tree.create_item(group)
	item.set_text(0, str(row.name))
	item.set_text(1, str(row.detail))
	item.set_text(2, READY_TEXT if bool(row.ready) else NOT_READY_TEXT)
	item.set_text(3, str(row.ping))
	item.set_metadata(0, str(row.key))
	if str(row.key) == selected_key:
		item.select(0)


func _selected_key() -> String:
	var item := tree.get_selected()
	return str(item.get_metadata(0)) if item != null and item.get_metadata(0) != null else ""


func _count_rows() -> int:
	var n := 0
	var root := tree.get_root()
	if root == null:
		return 0
	for group in root.get_children():
		n += group.get_child_count()
	return n
