class_name CommandMapView
extends Control
## The top-down picture of the command map (CommandMap; docs/COMMAND_MAP.md section 4): the battlefield
## (CommandMapBackground: the game's own world from above), the structures (friend / foe, dark when not working),
## the mission's nav points, what the viewer knows of (CommandMapKnowledge: friends; enemies only while his radar
## shows them; buildings his side owns or the mission names), the orders' points and the cursor. Units, base equipment and nav points wear the game's own map icons
## (CommandMapIcons) where it has them, else neutral shapes. Converts between world x/z and its pixels and
## finds what lies under a point (make_pick).

signal picked(pick: Dictionary)

const UNIT_RADIUS := 4.0
const OBJECT_SIZE := 7.0
const NAV_SIZE := 6.0
const PICK_RADIUS := 10.0
const CURSOR_SIZE := 8.0
const CURSOR_STEP := 12.0
const DARK := Color(0.25, 0.25, 0.25)
const ORDER_COLOR := Color(1.0, 0.85, 0.2)
## Friend or foe, as on the Tribes 2 command circuit (the side, not the team colour, which may be red).
const FRIEND_COLOR := Color(0.35, 0.95, 0.45)
const ENEMY_COLOR := Color(0.95, 0.25, 0.2)
const NAV_COLOR := Color(0.55, 0.95, 0.9)
const STRUCTURE_GROUP := "targetables"
const NAV_GROUP := "nav_points"
## A playable area larger than this (metres; an Earthsiege ground plane) is narrowed to where things are.
const MAX_AREA := 4000.0
const AREA_MARGIN := 300.0

var battle: Node3D
var viewer: Node3D
var area := Rect2()               # world x, z shown
var cursor := Vector2.ZERO        # pixels
var selected: Array = []          # net ids of the units being commanded
var background: Texture2D
var icons := CommandMapIcons.new()


func setup(p_battle: Node3D, p_viewer: Node3D) -> void:
	battle = p_battle
	viewer = p_viewer
	area = make_area(battle)
	icons = CommandMapIcons.load_for(CommandProviders.make_game_pack(battle))
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


## Builds the background picture (a render takes a couple of frames).
func build_background() -> void:
	background = await CommandMapBackground.make(battle, area)


## The area to show: the battle's playable area, else (none, or a vast ground plane) the square round everything on
## the battlefield (units, structures, nav points) with a margin.
static func make_area(p_battle: Node3D) -> Rect2:
	var bounds = p_battle.get("bounds")
	var rect: Rect2 = bounds.bounds.area if bounds and bounds.get("bounds") and bounds.bounds.has_area else Rect2()
	if rect.has_area() and maxf(rect.size.x, rect.size.y) <= MAX_AREA:
		return _square(rect)
	var box := Rect2()
	var found := false
	for group in ["vehicles", STRUCTURE_GROUP, NAV_GROUP]:
		for n in p_battle.get_tree().get_nodes_in_group(group):
			if n is Node3D and p_battle.is_ancestor_of(n):
				var p := Vector2((n as Node3D).global_position.x, (n as Node3D).global_position.z)
				box = Rect2(p, Vector2.ZERO) if not found else box.expand(p)
				found = true
	if not found:
		return Rect2(-Vector2.ONE * AREA_MARGIN, Vector2.ONE * AREA_MARGIN * 2.0)
	box = box.grow(AREA_MARGIN)
	return _square(box.intersection(rect) if rect.has_area() and rect.intersects(box) else box)


static func _square(r: Rect2) -> Rect2:
	var side := maxf(r.size.x, r.size.y)
	return Rect2(r.get_center() - Vector2.ONE * side * 0.5, Vector2.ONE * side)


func to_map(world: Vector3) -> Vector2:
	return (Vector2(world.x, world.z) - area.position) / area.size * size


func to_world(p: Vector2) -> Vector3:
	var xz := area.position + p / size * area.size
	var ground := CommandMapBackground._ground_at(battle, xz, 0.0)
	return Vector3(xz.x, ground, xz.y)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), CommandMapBackground.EMPTY_COLOR)
	if background:
		draw_texture_rect(background, Rect2(Vector2.ZERO, size), false)
	for s in make_structures():
		_draw_structure(s)
	for n in get_tree().get_nodes_in_group(NAV_GROUP):
		var p := to_map((n as Node3D).global_position)
		if not icons.draw(self, "nav", p, true, NAV_COLOR):
			draw_rect(Rect2(p - Vector2.ONE * NAV_SIZE * 0.5, Vector2.ONE * NAV_SIZE), NAV_COLOR, false, 1.5)
	for v in make_units():
		_draw_unit(v)
	_draw_raid_markers()
	for m in PersonalWaypoints.make_marks(viewer.global_position):
		UnitSymbols.draw_labeled_marker(self, to_map(m.pos), str(m.label), PersonalWaypoints.COLOR, ThemeDB.fallback_font, 14)
	var orders := CommandOrders.of(battle)
	if orders:
		for id in orders.orders:
			draw_circle(to_map(orders.make_point(orders.orders[id], orders.make_target(orders.orders[id]))), 3.0, ORDER_COLOR)
	draw_line(cursor - Vector2(CURSOR_SIZE, 0), cursor + Vector2(CURSOR_SIZE, 0), Color.WHITE, 1.0)
	draw_line(cursor - Vector2(0, CURSOR_SIZE), cursor + Vector2(0, CURSOR_SIZE), Color.WHITE, 1.0)


func _draw_structure(s: Node3D) -> void:
	var team := int(s.get("team")) if s.get("team") != null else -1
	var c := MapTeams.OTHER_TEAM_COLOR if team < 0 else (FRIEND_COLOR if _is_friend(s) else ENEMY_COLOR)
	var working := TribesBase.is_working(s)
	var p := to_map(s.global_position)
	if not icons.draw(self, CommandMapIcons.make_structure_kind(s), p, team < 0 or _is_friend(s), c if working else c * DARK):
		draw_rect(Rect2(p - Vector2.ONE * OBJECT_SIZE * 0.5, Vector2.ONE * OBJECT_SIZE), c if working else c * DARK, false, 2.0)


func _draw_unit(v: Node3D) -> void:
	var friendly := _is_friend(v)
	var c := FRIEND_COLOR if friendly else ENEMY_COLOR
	var p := to_map(v.global_position)
	if is_unit_symbology():
		if friendly:
			UnitSymbols.draw_arrow(self, p, UnitSymbols.make_facing(v), c, 1.3 if v == viewer else 1.0)
		else:
			UnitSymbols.draw_square(self, p, c)
	elif not icons.draw(self, icons.make_unit_kind(v, v == viewer), p, friendly, c):
		UnitSymbols.draw_arrow(self, p, UnitSymbols.make_facing(v), c) if friendly else UnitSymbols.draw_square(self, p, c)
	if selected.has(int(v.net_id)) or v == viewer:
		draw_arc(p, UNIT_RADIUS + 3.0, 0.0, TAU, 16, Color.WHITE, 1.5)


## True in an extraction raid: every unit wears the arrow (team) / square (contact) symbols, not the game's icons.
func is_unit_symbology() -> bool:
	return battle != null and battle.get("extraction") != null


## Extraction zones ("EXFIL A") and the player's task targets, as labelled markers.
func _draw_raid_markers() -> void:
	var ex = battle.get("extraction")
	if not (ex is ExtractionDirector):
		return
	var font := ThemeDB.fallback_font
	for i in ex.zones.size():
		UnitSymbols.draw_labeled_marker(self, to_map(ex.zones[i]), "EXFIL %s" % ExtractionTransports.make_zone_name(i),
			Color(0.4, 1.0, 0.6), font, 14)
	if ex.tasks != null:
		for m in ex.tasks.make_markers():
			UnitSymbols.draw_labeled_marker(self, to_map(m.pos), str(m.label), Color(1.0, 0.95, 0.3), font, 14)


func _is_friend(v: Node) -> bool:
	return TeamRelations.is_allied(int(viewer.get("team")), int(v.get("team")))


## The live combatants the viewer's side knows of: friends, enemies on his radar now (CommandMapKnowledge).
func make_units() -> Array:
	return get_tree().get_nodes_in_group("vehicles").filter(func(v: Node) -> bool:
		return v.alive and not (v is Infantry and (v as Infantry).stowed) and CommandMapKnowledge.is_unit_known(viewer, v))


## The standing structures of the battlefield the viewer knows of (CommandMapKnowledge: his side's, Tribes bases,
## the mission's targets, his locked target).
func make_structures() -> Array:
	var known := CommandMapKnowledge.make_mission_targets(battle)
	return get_tree().get_nodes_in_group(STRUCTURE_GROUP).filter(func(s: Node) -> bool:
		return s is Node3D and bool(s.get("alive")) and battle.is_ancestor_of(s) and 			CommandMapKnowledge.is_structure_known(viewer, s, known))


## What is at map point `p`: {menu, point: Vector3, target: net id, object: node path, name}: the viewer himself,
## another combatant, a structure, a nav point, else the place.
func make_pick(p: Vector2) -> Dictionary:
	if to_map(viewer.global_position).distance_to(p) <= PICK_RADIUS:
		return {"menu": "self", "point": viewer.global_position, "target": 0, "object": "", "name": "you"}
	for v in make_units():
		if v != viewer and to_map(v.global_position).distance_to(p) <= PICK_RADIUS:
			return {"menu": "player_friend" if _is_friend(v) else "player_enemy", "point": v.global_position,
				"target": int(v.net_id), "object": "", "name": str(v.display_name)}
	for s in make_structures():
		if to_map(s.global_position).distance_to(p) <= PICK_RADIUS:
			return {"menu": "object_friend" if _is_friend(s) else "object_enemy", "point": s.global_position,
				"target": 0, "object": str(battle.get_path_to(s)), "name": str(s.get("display_name"))}
	for n in get_tree().get_nodes_in_group(NAV_GROUP):
		if to_map((n as Node3D).global_position).distance_to(p) <= PICK_RADIUS:
			return {"menu": "nav", "point": (n as Node3D).global_position, "target": 0, "object": "",
				"name": str(n.get_meta("label", "nav point"))}
	return {"menu": "location", "point": to_world(p), "target": 0, "object": "", "name": "waypoint"}


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		cursor = (event as InputEventMouseMotion).position
	elif event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		cursor = (event as InputEventMouseButton).position
		picked.emit(make_pick(cursor))
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		picked.emit(make_pick(cursor))
		accept_event()
	else:
		_move_cursor(event)


## Keyboard / gamepad: the ui directions move the cursor over the map.
func _move_cursor(event: InputEvent) -> void:
	var step := Vector2.ZERO
	for pair in [["ui_left", Vector2.LEFT], ["ui_right", Vector2.RIGHT], ["ui_up", Vector2.UP], ["ui_down", Vector2.DOWN]]:
		if event.is_action_pressed(str(pair[0]), true):
			step += pair[1]
	if step != Vector2.ZERO:
		cursor = (cursor + step * CURSOR_STEP).clamp(Vector2.ZERO, size)
		accept_event()
