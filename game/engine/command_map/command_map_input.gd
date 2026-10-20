class_name CommandMapInput
extends Node
## Opens and closes the command map with the command_map action (N; pad: hold Back; docs/COMMAND_MAP.md section 5;
## child "CommandMapInput" of the Battle). It opens for the local player's unit when the battle has orders
## (CommandOrders), his game lets him open it anywhere (CommandProvider.can_open_anywhere; a game may tie it to a
## station), the mission's script has not taken the key (Tribes 2 Training 1-3) and his side has its sensor link
## (SensorLink: a campaign story can take the radar away); otherwise it says why on the HUD.

const NODE_NAME := "CommandMapInput"
const ACTION := "command_map"
## make_refusal: the mission's script answers the key itself.
const MISSION_TEXT := "mission"
const MESSAGE_SECONDS := 3.0
const STATION_ONLY_TEXT := "Command map: use a command station"

var battle: Node3D
## Pad: holding view_toggle (Back) opens it (SiegeInput.HELD_ACTIONS).
var _pad_hold := HeldAction.new(ACTION)


static func build_for(p_battle: Node3D) -> CommandMapInput:
	var n := CommandMapInput.new()
	n.battle = p_battle
	n.name = NODE_NAME
	ServerProfile.apply_client_only(n)
	p_battle.add_child(n)
	return n


## A campaign mission whose script took the command-map key (Tribes 2 Training 1-3: is_command_map_taken).
static func is_taken_by_mission(p_battle: Node) -> bool:
	var mission = p_battle.get("mission")
	return mission != null and mission.has_method("is_command_map_taken") and mission.is_command_map_taken()


## Why the local player may not open the command map now ("" when he may; "-" silently; MISSION_TEXT: the
## mission's script answers).
static func make_refusal(p_battle: Node, unit: Node, anywhere: bool) -> String:
	var orders := CommandOrders.of(p_battle)
	if orders == null or unit == null or not bool(unit.get("alive")):
		return "-"
	if is_taken_by_mission(p_battle):
		return MISSION_TEXT
	if not SensorLink.is_up(p_battle):
		return SensorLink.DOWN_TEXT
	if anywhere and not orders.provider.can_open_anywhere():
		return STATION_ONLY_TEXT
	return ""


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(ACTION) or ChatFocus.open:
		return
	if CommandMap.find_open(battle):
		return       # the map closes itself on the same action
	apply_toggle()
	get_viewport().set_input_as_handled()


## Opens the command map for the local player (or says on the HUD why it cannot open); closes an open one.
func apply_toggle() -> void:
	var open_map := CommandMap.find_open(battle)
	if open_map:
		open_map.close()
		return
	if battle.has_method("is_over") and battle.is_over():
		return
	var orders := CommandOrders.of(battle)
	var unit: Node3D = orders.make_commander_of(multiplayer.get_unique_id()) if orders else null
	var refusal := make_refusal(battle, unit, true)
	if refusal == "":
		CommandMap.open(battle, unit)
	elif refusal == MISSION_TEXT:
		battle.mission.run_command_map_key()      # the mission's script answers in its own words
	elif refusal != "-" and battle.has_method("fx"):
		battle.fx("message", [refusal, MESSAGE_SECONDS])


func _process(delta: float) -> void:
	_pad_hold.advance(delta)
	if _pad_hold.just_fired:
		apply_toggle()
	var open_map := CommandMap.find_open(battle)
	if open_map and not SensorLink.is_up(battle):
		open_map.close()        # the story took the radar away while the map was open
