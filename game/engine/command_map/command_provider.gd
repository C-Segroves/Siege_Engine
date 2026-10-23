class_name CommandProvider
extends RefCounted
## What a game brings to the command map (docs/COMMAND_MAP.md section 3): its own orders, who may open the map
## where, and how a unit acknowledges an order. The base class is the remake's shared set, for games without
## wingman or squad commands; a game overrides it (WingmanCommandProvider: Earthsiege 1 / 2, StarsiegeCommandProvider,
## TribesCommandProvider).
##
## Menus by what was picked on the map: "self" (the commander himself), "location", "nav" (a nav point),
## "player_friend", "player_enemy", "object_friend", "object_enemy", "flag_friend", "flag_enemy", "objective".
## An entry: {key: hotkey letter, label, kind: CommandGoal kind, task: the original's order id (or the remake's),
## message: what the unit is told, ack: the provider's acknowledgement data}.

## The remake's shared set (no original): attack target, defend point, move to, escort me, regroup on me.
const REMAKE_MENUS := {
	"self": [{"key": "e", "label": "Escort me", "kind": CommandGoal.ESCORT, "task": "escort_me", "message": "Escort me"},
		{"key": "r", "label": "Regroup on me", "kind": CommandGoal.REGROUP, "task": "regroup", "message": "Regroup on me"}],
	"location": [{"key": "m", "label": "Move to", "kind": CommandGoal.MOVE, "task": "move", "message": "Move to the waypoint"},
		{"key": "d", "label": "Defend point", "kind": CommandGoal.DEFEND, "task": "defend", "message": "Defend the waypoint"}],
	"nav": [{"key": "m", "label": "Move to", "kind": CommandGoal.MOVE, "task": "move", "message": "Move to the nav point"},
		{"key": "d", "label": "Defend point", "kind": CommandGoal.DEFEND, "task": "defend", "message": "Defend the nav point"}],
	"player_enemy": [{"key": "a", "label": "Attack target", "kind": CommandGoal.ATTACK, "task": "attack", "message": "Attack"}],
	"object_enemy": [{"key": "a", "label": "Attack target", "kind": CommandGoal.ATTACK, "task": "attack", "message": "Destroy"}],
	"object_friend": [{"key": "d", "label": "Defend point", "kind": CommandGoal.DEFEND, "task": "defend", "message": "Defend"}],
	"player_friend": [{"key": "e", "label": "Escort", "kind": CommandGoal.ESCORT, "task": "escort", "message": "Escort"}],
}
## Spacing of the remake's formation slots behind the commander (metres).
const FORMATION_SPACING := 12.0


## Short name shown in the map's title ("" = the remake's).
func make_title() -> String:
	return "COMMAND MAP"


## The orders by menu.
func make_menus() -> Dictionary:
	return REMAKE_MENUS


## True when the command map may be opened anywhere with the command_map key (Tribes 1: only at a station).
func can_open_anywhere() -> bool:
	return true


## True when `commander` may give orders to `unit`: an allied, living combatant other than himself.
func can_command(commander: Node, unit: Node) -> bool:
	return unit != commander and is_instance_valid(unit) and bool(unit.get("alive")) and \
		TeamRelations.is_allied(int(commander.get("team")), int(unit.get("team")))


## How `unit` takes `commander`'s order `entry` aimed at `where` ([point, target net id, object path]): {where (the
## order's own target where the game picks it: "attack my target"), refused (he will not or cannot), reply (the
## game's answer, for make_ack_line)}. The remake's set takes every order as given.
func resolve_order(_battle: Node, _commander: Node, _unit: Node, _entry: Dictionary, where: Array) -> Dictionary:
	return {"where": where, "refused": false, "reply": ""}


## Speaks `unit`'s answer to `entry` (`outcome`: resolve_order's) on the radio (every peer; nothing when the game
## has none).
func acknowledge(battle: Node, unit: Node, entry: Dictionary, outcome := {}) -> void:
	var line := make_ack_line(unit, entry, outcome)
	if not line.is_empty() and battle.has_method("radio"):
		battle.radio(str(line.speaker), str(line.text), str(line.voice))


## `unit`'s answer to `entry` (RadioLine.make: speaker, text, voice clip), {} for none. The remake's set has no
## voices: a text line.
func make_ack_line(unit: Node, entry: Dictionary, outcome := {}) -> Dictionary:
	var text := "Unable to comply" if bool(outcome.get("refused", false)) else "Acknowledged: %s" % str(entry.get("label", ""))
	return RadioLine.make(str(unit.get("display_name")), text, "")


## `unit`'s answer when called up for an order ({} when the game has none; Starsiege: CR).
func make_call_up_line(_unit: Node) -> Dictionary:
	return {}


## The game's squad keys outside the map (SquadKeys; Starsiege F1-F4 then 1-7): false when it has none.
func has_squad_keys() -> bool:
	return false


## The unit's slot behind `commander` (its leader frame), for formation orders: rows of three.
func make_formation_offset(index: int) -> Vector3:
	return Formation.rows_slot(index, FORMATION_SPACING)
