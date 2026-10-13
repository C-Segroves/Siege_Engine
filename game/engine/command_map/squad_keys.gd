class_name SquadKeys
extends Node
## A game's squad keys outside the command map (docs/COMMAND_MAP.md section 3.2; child "SquadKeys" of the Battle
## when the provider has them, CommandProvider.has_squad_keys): Starsiege's F1-F3 call up squadmate 1-3 and F4 the
## whole squad (cockpit_mode_1..4, the same keys); the squadmate answers (CR) and the HUD lists the squad menu, whose
## number keys (the original's typed hotkeys, like the map's letters) give the order on the player himself ("self"
## menu: Attack My Target, Join On Me, ...). The menu closes after MENU_SECONDS, on menu_back or on another call-up.

const NODE_NAME := "SquadKeys"
## cockpit_mode_1..3: squadmate 1..3; cockpit_mode_4: the squad.
const CALL_ACTIONS := ["cockpit_mode_1", "cockpit_mode_2", "cockpit_mode_3", "cockpit_mode_4"]
const SQUAD_SLOTS := 3
const MENU_SECONDS := 6.0

var battle: Node3D
## Net ids called up; empty when no squad menu is open.
var called: Array = []
var _menu_left := 0.0


static func build_for(p_battle: Node3D, provider: CommandProvider) -> SquadKeys:
	if not provider.has_squad_keys():
		return null
	var n := SquadKeys.new()
	n.battle = p_battle
	n.name = NODE_NAME
	p_battle.add_child(n)
	return n


## True when `p_battle` has squad keys and `action` is one of them (the cockpit leaves those keys to it).
static func owns(p_battle: Node, action: String) -> bool:
	return p_battle != null and p_battle.has_node(NODE_NAME) and CALL_ACTIONS.has(action)


func _input(event: InputEvent) -> void:
	if ChatFocus.open or CommandMap.find_open(battle):
		return
	for i in CALL_ACTIONS.size():
		if event.is_action_pressed(CALL_ACTIONS[i]):
			call_up(i)
			get_viewport().set_input_as_handled()
			return
	if called.is_empty():
		return
	if UiActions.is_back(event):
		close_menu()
		get_viewport().set_input_as_handled()
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.unicode > 0 and give_by_key(char(key.unicode)):
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if called.is_empty():
		return
	_menu_left -= delta
	if _menu_left <= 0.0:
		close_menu()


## Calls up squadmate `slot` (0..2) or, past them, the whole squad: he answers and the squad menu shows.
func call_up(slot: int) -> void:
	var orders := CommandOrders.of(battle)
	var me: Node3D = orders.make_commander_of(multiplayer.get_unique_id()) if orders else null
	if me == null:
		return
	var squad := make_squad(orders, me)
	called = squad.slice(slot, slot + 1) if slot < SQUAD_SLOTS else squad
	if called.is_empty():
		return
	orders.request_call_up(called)
	_menu_left = MENU_SECONDS
	if battle.has_method("fx"):
		battle.fx("message", [make_menu_text(orders), MENU_SECONDS])


## The player's squadmates in squad order (net ids).
static func make_squad(orders: CommandOrders, me: Node3D) -> Array:
	var brains := orders.make_brains()
	var ids := orders.make_commandable(me).map(func(v: Node) -> int: return int(v.net_id)).filter(
		func(id: int) -> bool: return brains.has(id))
	ids.sort()
	return ids


static func make_menu_text(orders: CommandOrders) -> String:
	var parts := []
	for e in orders.make_menu("self"):
		parts.append("%s %s" % [str(e.key), str(e.label)])
	return "  ".join(parts)


## The squad menu's order with hotkey `key` to the called-up units (true when one matched).
func give_by_key(key: String) -> bool:
	var orders := CommandOrders.of(battle)
	var me: Node3D = orders.make_commander_of(multiplayer.get_unique_id()) if orders else null
	if me == null:
		return false
	for e in orders.make_menu("self"):
		if str(e.key) == key:
			orders.request_order(e, called, me.global_position)
			close_menu()
			return true
	return false


func close_menu() -> void:
	called = []
	_menu_left = 0.0
