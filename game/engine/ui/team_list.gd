class_name TeamList
extends VBoxContainer
## The teams of a team match (host screen and lobby), side by side: an "Unassigned" column (grey) for pilots who
## have not picked a team and were not placed yet, then one column per team with its colour and name; each member
## (pilot, infantry bot or AI unit) is one row in his team's column. A pilot picks his own team in his row's picker; the
## host may move anyone and has "Assign all" (the unassigned onto the smallest teams, bots counted) and "Shuffle
## teams". The columns share the width; when they would get too narrow they wrap two per row. Rebuilt only when
## what it shows changes, so focus stays put.
##   refresh(settings, roster, my_id, is_host)
##   team_chosen(peer, team) / assign_all_requested / shuffle_requested

signal team_chosen(peer: int, team: int)
signal member_team_chosen(key: String, team: int)
signal assign_all_requested
signal shuffle_requested

const UNASSIGNED := TeamAssignment.UNASSIGNED
const UNASSIGNED_NAME := "Unassigned"
const UNASSIGNED_COLOR := Color(0.55, 0.58, 0.6)
const SWATCH_SIZE := Vector2(18, 18)
const ICON_SIZE := 14
const MIN_COLUMN_WIDTH := 210.0
const NARROW_COLUMNS := 2
const PICKER_WIDTH := 145.0
const PICKER_ID_OFFSET := 1

var _key := ""
var _grid: GridContainer
var _column_count := 1


func _init() -> void:
	resized.connect(_apply_columns)


## Shows the teams of lobby settings `settings` with `roster` (Net.roster); `my_id` / `is_host`: who may change
## which pilot's team.
func refresh(settings: Dictionary, roster: Dictionary, my_id: int, is_host: bool) -> void:
	var key := JSON.stringify([settings, _make_roster_key(roster), my_id, is_host])  # settings include member_teams
	if key == _key:
		return
	_key = key
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var count := LobbySettings.make_team_count(settings)
	var view := {"roster": roster, "bots": LobbySettings.make_planned_members(settings), "count": count, "my_id": my_id,
		"is_host": is_host, "map_config": LobbySettings.make_map_config(settings)}
	add_child(Widgets.section("Teams (%d)" % count))
	if is_host:
		add_child(Widgets.row([Widgets.small_button("Assign all", func() -> void: assign_all_requested.emit()),
			Widgets.small_button("Shuffle teams", func() -> void: shuffle_requested.emit())]))
	_grid = GridContainer.new()
	add_child(_grid)
	_column_count = count + 1
	_add_column(UNASSIGNED, view)
	for team in count:
		_add_column(team, view)
	_apply_columns()


static func _make_roster_key(roster: Dictionary) -> Array:
	var out := []
	for id in roster:
		out.append([int(id), str(roster[id].get("name", "")), int(roster[id].get("team", UNASSIGNED))])
	return out


## Every column side by side while each keeps MIN_COLUMN_WIDTH, else two per row.
func _apply_columns() -> void:
	if _grid == null:
		return
	var fits := size.x <= 0.0 or size.x / _column_count >= MIN_COLUMN_WIDTH
	_grid.columns = _column_count if fits else NARROW_COLUMNS


## Team `team`'s column (UNASSIGNED: the waiting pilots): its colour and name, then one row per member.
func _add_column(team: int, view: Dictionary) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var swatch := ColorRect.new()
	swatch.color = make_team_color(team)
	swatch.custom_minimum_size = SWATCH_SIZE
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	column.add_child(Widgets.row([swatch, Widgets.label(make_team_name(team, view.map_config))]))
	var members := 0
	for id in view.roster:
		if _team_of(view.roster[id], view.count) == team:
			column.add_child(_make_pilot_row(int(id), view.roster[id], view))
			members += 1
	for bot in view.bots:
		if int(bot.team) == team:
			column.add_child(_make_bot_row(bot, view))
			members += 1
	if members == 0:
		column.add_child(Widgets.label("(nobody)" if team != UNASSIGNED else "(everyone has a team)", "DimLabel"))


## A pilot's team, UNASSIGNED for none or a team the match does not have.
static func _team_of(entry: Dictionary, count: int) -> int:
	var t := int(entry.get("team", UNASSIGNED))
	return t if t >= 0 and t < count else UNASSIGNED


static func make_team_name(team: int, map_config: Dictionary) -> String:
	return UNASSIGNED_NAME if team == UNASSIGNED else CatalogBridge.make_team_name(team, map_config)


static func make_team_color(team: int) -> Color:
	return UNASSIGNED_COLOR if team == UNASSIGNED else CatalogBridge.make_team_color(team)


## A computer-controlled member's row: name and kind; the host also gets a team picker (member_team_chosen).
func _make_bot_row(bot: Dictionary, view: Dictionary) -> Control:
	var label := Widgets.label("%s  (%s)" % [bot.name, bot.kind], "DimLabel")
	if not bool(view.is_host):
		return label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	var picker := _make_team_picker(int(bot.team), int(view.count), view.map_config, false)
	picker.tooltip_text = "Team of %s" % bot.name
	var key := str(bot.key)
	picker.item_selected.connect(func(i: int) -> void: member_team_chosen.emit(key, picker.get_item_id(i) - PICKER_ID_OFFSET))
	return Widgets.row([label, picker])


## The member row: name, and the team picker (his own row, or every row for the host).
func _make_pilot_row(id: int, entry: Dictionary, view: Dictionary) -> Control:
	var text := "%s%s" % [entry.get("name", "?"), " (you)" if id == int(view.my_id) else ""]
	var name_label := Widgets.label(text)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	if id != int(view.my_id) and not bool(view.is_host):
		return name_label
	var picker := _make_team_picker(_team_of(entry, int(view.count)), int(view.count), view.map_config)
	picker.tooltip_text = "Team of %s" % entry.get("name", "?")
	picker.item_selected.connect(func(i: int) -> void: team_chosen.emit(id, picker.get_item_id(i) - PICKER_ID_OFFSET))
	return Widgets.row([name_label, picker])


## Unassigned and every team, each with its colour; `current` selected (item id = team + PICKER_ID_OFFSET: an id of
## -1 would mean "use the index").
static func _make_team_picker(current: int, count: int, map_config: Dictionary, with_unassigned := true) -> OptionButton:
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(PICKER_WIDTH, 0)
	picker.clip_text = true
	for team in range(UNASSIGNED if with_unassigned else 0, count):
		picker.add_icon_item(_make_swatch_icon(make_team_color(team)), make_team_name(team, map_config), team + PICKER_ID_OFFSET)
	picker.select(picker.get_item_index(current + PICKER_ID_OFFSET))
	return picker


static func _make_swatch_icon(c: Color) -> ImageTexture:
	var img := Image.create(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
