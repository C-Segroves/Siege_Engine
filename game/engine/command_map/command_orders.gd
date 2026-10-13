class_name CommandOrders
extends Node
## The orders players give their wingmen, squadmates and teammates on the command map (child "CommandOrders" of the
## Battle; docs/COMMAND_MAP.md). Every game and mode: the game's provider (CommandProviders.make_for) brings its own
## orders; this node carries them out, host-authoritative:
##   AI units  (AIPilot, InfantryBot; a bot driving a vehicle) follow the order instead of their game mode plan or
##             mission orders: GameModeBrains calls apply_to_brains after its plan, without a game mode director
##             this node applies them itself. A formation order sets the AIPilot's leader and slot; the unit's
##             mission leader comes back when the order ends.
##   players   get the order as a message and a waypoint (nav point).
## An order lasts until it is done (CommandGoal.is_done: target destroyed, place reached), replaced, or failed (the
## escorted unit died): order_finished(net id, order, success) then fires and the brain's own plan resumes.
## The ordered unit acknowledges on the radio (the provider: the game's own wingman lines).
## Requests go to the host, which checks the commander may order those units; orders replicate to every peer.

signal orders_changed
## An order ended: done (success) or failed (its escorted unit died). Not sent for replaced orders.
signal order_finished(net_id: int, order: Dictionary, success: bool)

const NODE_NAME := "CommandOrders"
const APPLY_SECONDS := 1.0
const MESSAGE_SECONDS := 5.0
const WAYPOINT_GROUP := "nav_points"
## The game mode director's node (GameModeDirector): it applies the orders after its own plan when present.
const GAME_MODES_NODE := "GameModes"
const BOT_DRIVER_NODE := "BotDriver"

var battle: Node
var provider: CommandProvider
var menus: Dictionary = {}
## net id -> {kind, task, label, text, point: Vector3, target: net id (0), object: node path (""), commander: net id,
## had_target: bool, from: commander's name}
var orders: Dictionary = {}
var _apply_t := 0.0
var _waypoint: Marker3D
var _saved_leaders := {}         # net id -> [leader, formation_offset] of AIPilots in an ordered formation


## The battle's orders with `p_provider`'s menus (entries of unknown kinds are left out).
static func build_for(p_battle: Node, p_provider: CommandProvider) -> CommandOrders:
	var o := CommandOrders.new()
	o.battle = p_battle
	o.name = NODE_NAME
	o.provider = p_provider
	var all := p_provider.make_menus()
	for menu in all:
		o.menus[menu] = (all[menu] as Array).filter(func(e: Dictionary) -> bool: return CommandGoal.is_known(str(e.get("kind", ""))))
	p_battle.add_child(o)
	return o


static func of(p_battle: Node) -> CommandOrders:
	return p_battle.get_node_or_null(NODE_NAME) as CommandOrders if p_battle else null


## The orders offered for a pick of `menu`.
func make_menu(menu: String) -> Array:
	return menus.get(menu, [])


## The units `commander` may order (the provider's rule), live combatants of the battle.
func make_commandable(commander: Node) -> Array:
	var brains := make_brains()
	return battle.vehicles.values().filter(func(v: Node) -> bool:
		var crewed: bool = brains.has(int(v.net_id)) or int(v.get("owner_peer")) > 0     # an empty vehicle takes no orders
		return is_instance_valid(v) and crewed and not (v is Infantry and (v as Infantry).stowed) and provider.can_command(commander, v))


# ------------------------------------------------------------------ giving orders

## Asks the host to give `units` (net ids) the order `entry` at `point`, on `target` (a combatant's net id, else 0)
## or `object` (a structure's node path from the battle, else "").
func request_order(entry: Dictionary, units: Array, point: Vector3, target := 0, object := "") -> void:
	if multiplayer.is_server():
		apply_order(multiplayer.get_unique_id(), entry, units, [point, target, object])
	else:
		_request_order.rpc_id(1, entry, units, [point, target, object])


@rpc("any_peer", "reliable")
func _request_order(entry: Dictionary, units: Array, where: Array) -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_order(multiplayer.get_remote_sender_id(), entry, units, where)


## Calls up `units` (net ids) for an order (Starsiege F1-F4): each answers in the game's words (the host speaks
## on every peer's radio; CommandProvider.make_call_up_line).
func request_call_up(units: Array) -> void:
	if multiplayer.is_server():
		apply_call_up(multiplayer.get_unique_id(), units)
	else:
		_request_call_up.rpc_id(1, units)


@rpc("any_peer", "reliable")
func _request_call_up(units: Array) -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_call_up(multiplayer.get_remote_sender_id(), units)


## Host: the first unit of `units` `peer`'s unit may command answers the call-up (one answer, as for an order to
## the whole squad).
func apply_call_up(peer: int, units: Array) -> void:
	var commander := make_commander_of(peer)
	for id in units:
		var unit = battle.vehicles.get(int(id))
		if commander and is_instance_valid(unit) and provider.can_command(commander, unit):
			var line := provider.make_call_up_line(unit)
			if not line.is_empty() and battle.has_method("radio"):
				battle.radio(str(line.speaker), str(line.text), str(line.voice))
			return


## Host: `peer`'s unit orders `units`; where = [point, target net id, object path]. Only orders of the provider's
## menus are carried out.
func apply_order(peer: int, entry: Dictionary, units: Array, where: Array) -> void:
	var commander := make_commander_of(peer)
	if commander == null or not _is_offered(entry):
		return
	var index := 0
	for id in units:
		var unit = battle.vehicles.get(int(id))
		if not provider.can_command(commander, unit):
			continue
		var outcome := provider.resolve_order(battle, commander, unit, entry, where)
		if _is_ai(unit):
			provider.acknowledge(battle, unit, entry, outcome)
		if bool(outcome.get("refused", false)):
			continue
		var at: Array = outcome.get("where", where)
		_set_order(int(id), {"kind": str(entry.kind), "task": str(entry.task), "label": str(entry.get("label", entry.task)),
			"text": make_text(entry, at), "point": at[0], "target": int(at[1]), "object": str(at[2]),
			"commander": int(commander.net_id), "had_target": int(at[1]) != 0 or str(at[2]) != "",
			"from": str(commander.display_name), "slot": index})
		index += 1


## The unit `peer` plays: his soldier on foot, else the vehicle he drives (the local player of a campaign mission).
func make_commander_of(peer: int) -> Node:
	var occupancy = battle.get("occupancy")
	var s = occupancy.soldier_of(peer) if occupancy else null
	if s and not (s as Infantry).stowed:
		return s
	if s and (s as Infantry).seat:
		return (s as Infantry).seat.vehicle
	for v in battle.vehicles.values():
		if is_instance_valid(v) and int(v.get("owner_peer")) == peer and not (v is Infantry):
			return v
	var player = battle.get("player")      # a campaign mission's own player (Tribes training: no seat bookkeeping)
	if peer == multiplayer.get_unique_id() and player is Node3D and is_instance_valid(player):
		return player
	return null


func _is_offered(entry: Dictionary) -> bool:
	for menu in menus.values():
		for e in menu:
			if str(e.task) == str(entry.get("task", "")) and str(e.kind) == str(entry.get("kind", "")):
				return true
	return false


## The order's message: the game's text, with the target's name for orders on a combatant.
func make_text(entry: Dictionary, where: Array) -> String:
	var text := str(entry.get("message", entry.get("label", "")))
	var target = battle.vehicles.get(int(where[1]))
	if is_instance_valid(target) and not text.contains(str(target.display_name)) and str(entry.kind) in [CommandGoal.ATTACK, CommandGoal.ESCORT]:
		text += " " + str(target.display_name)
	return text


func _set_order(id: int, order: Dictionary) -> void:
	_receive_order(id, order)
	if Net.is_online():
		_receive_order.rpc(id, order)


@rpc("authority", "call_remote", "reliable")
func _receive_order(id: int, order: Dictionary) -> void:
	if order.is_empty():
		orders.erase(id)
	else:
		orders[id] = order
	if id == _local_net_id():
		_show_to_player(order)
	orders_changed.emit()


## Host: ends `id`'s order (its brains go back to their own plan).
func clear_order(id: int) -> void:
	if not orders.has(id):
		return
	_release_brains(id)
	_set_order(id, {})


# ------------------------------------------------------------------ carrying them out

## The brain objective ({point, urgent, radius, hold, target}) of `id`'s order now ({} for none / formation).
func make_objective(id: int) -> Dictionary:
	var order: Dictionary = orders.get(id, {})
	if order.is_empty():
		return {}
	var target := make_target(order)
	return CommandGoal.make_objective(str(order.kind), make_point(order, target), target)


## The order's live target: the combatant, the structure, the commander for orders on himself.
func make_target(order: Dictionary) -> Node3D:
	var id := int(order.target)
	if id == 0 and str(order.kind) in [CommandGoal.ESCORT, CommandGoal.REGROUP, CommandGoal.FORMATION]:
		id = int(order.commander)
	var unit = battle.vehicles.get(id)
	if id != 0 and is_instance_valid(unit) and unit.alive:
		return unit
	if str(order.object) != "":
		var o := battle.get_node_or_null(NodePath(str(order.object))) as Node3D
		if o and bool(o.get("alive")):
			return o
	return null


func make_point(order: Dictionary, target: Node3D) -> Vector3:
	if target and str(order.kind) != CommandGoal.HOLD:
		return target.global_position
	return order.point


## Host: overrides the brains of every ordered unit (`brains`: net id -> [brain nodes]; GameModeBrains calls this
## after its own plan).
func apply_to_brains(brains: Dictionary) -> void:
	for id in brains:
		if orders.has(int(id)):
			_apply_brains(int(id), brains[id])


func _apply_brains(id: int, list: Array) -> void:
	var order: Dictionary = orders[id]
	var objective := make_objective(id)
	for brain in list:
		if str(order.kind) == CommandGoal.FORMATION and brain is AIPilot:
			_apply_formation(id, brain as AIPilot, order)
		else:
			brain.set("objective", objective if str(order.kind) != CommandGoal.FORMATION else \
				CommandGoal.make_objective(CommandGoal.ESCORT, make_point(order, make_target(order)), null))


func _apply_formation(id: int, pilot: AIPilot, order: Dictionary) -> void:
	var leader = battle.vehicles.get(int(order.commander))
	if not _saved_leaders.has(id):
		_saved_leaders[id] = [pilot.leader, pilot.formation_offset]
	pilot.objective = {}
	pilot.leader = leader if is_instance_valid(leader) else null
	pilot.formation_offset = provider.make_formation_offset(int(order.get("slot", 0)))


func _release_brains(id: int) -> void:
	for brain in make_brains().get(id, []):
		brain.set("objective", {})
		if brain is AIPilot and _saved_leaders.has(id):
			(brain as AIPilot).leader = _saved_leaders[id][0]
			(brain as AIPilot).formation_offset = _saved_leaders[id][1]
	_saved_leaders.erase(id)


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or orders.is_empty():
		return
	_apply_t -= delta
	if _apply_t > 0.0:
		return
	_apply_t = APPLY_SECONDS
	_check_finished()
	if battle.get_node_or_null(GAME_MODES_NODE) == null:
		apply_to_brains(make_brains())


## Host: ends the orders that are done or failed (order_finished), and those of dead units.
func _check_finished() -> void:
	for id in orders.keys():
		var order: Dictionary = orders[id]
		var unit = battle.vehicles.get(int(id))
		if not is_instance_valid(unit) or not unit.alive:
			clear_order(int(id))
			order_finished.emit(int(id), order, false)      # the ordered unit is gone
			continue
		var target := make_target(order)
		var kind := str(order.kind)
		var failed := CommandGoal.is_failed(kind, target, bool(order.had_target))
		if failed or CommandGoal.is_done(kind, unit, make_point(order, target), target, bool(order.had_target)):
			clear_order(int(id))
			order_finished.emit(int(id), order, not failed)


## net id -> the brains that move it: its AIPilot (when running) and InfantryBot, the AIPilot of the vehicle a bot
## drives.
func make_brains() -> Dictionary:
	var out := {}
	for h in battle.vehicles.values():
		if not is_instance_valid(h) or h.has_meta(GameModeBrains.DEFENDER_META):
			continue
		var list: Array = h.get_children().filter(func(c: Node) -> bool:
			return c is InfantryBot or (c is AIPilot and c.is_physics_processing()))
		var soldier := h as Infantry
		if soldier and soldier.stowed and soldier.seat != null and soldier.seat.seat == VehicleOccupancy.PILOT_SEAT:
			var driver := soldier.seat.vehicle.get_node_or_null(BOT_DRIVER_NODE)
			if driver is AIPilot:
				list.append(driver)
		if not list.is_empty():
			out[h.net_id] = list
	return out


func _is_ai(unit: Node) -> bool:
	return make_brains().has(int(unit.net_id))


# ------------------------------------------------------------------ players

func _local_net_id() -> int:
	var c := make_commander_of(multiplayer.get_unique_id())
	return int(c.net_id) if c else -1


func _show_to_player(order: Dictionary) -> void:
	if is_instance_valid(_waypoint):
		_waypoint.queue_free()
	if order.is_empty():
		return
	if battle.has_method("fx"):
		battle.fx("message", ["%s: %s" % [order.get("from", "Commander"), order.text], MESSAGE_SECONDS])
	_waypoint = Marker3D.new()
	_waypoint.name = "CommandWaypoint"
	_waypoint.position = order.point
	_waypoint.set_meta("label", str(order.label))
	_waypoint.add_to_group(WAYPOINT_GROUP)
	battle.add_child(_waypoint)
