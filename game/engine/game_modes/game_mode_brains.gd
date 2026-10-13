class_name GameModeBrains
extends Node
## Host: hands the game mode's AI goals (GameModeAI) to the brains every THINK_SECONDS - InfantryBot.objective for
## soldiers (a bot piloting a vehicle: the vehicle's AIPilot), AIPilot.objective for AI vehicles. Base defenders
## (meta DEFENDER_META, WAR) keep their guard orders. Child "Brains" of GameModeDirector.

const THINK_SECONDS := 1.0
const DEFENDER_META := "mode_defender"

var director: GameModeDirector
var _think := 0.0


func _init(p_director: GameModeDirector) -> void:
	director = p_director
	name = "Brains"


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or director.rules.over:
		return
	_think -= delta
	if _think > 0.0:
		return
	_think = THINK_SECONDS
	apply_goals()


## Plans and hands out the goals now.
func apply_goals() -> void:
	var brains := make_brains()
	var goals := GameModeAI.make_goals(director.rules, director.make_players(), brains.keys(),
		director.map_data.get("ai_objectives", []))
	for id in brains:
		var objective := make_objective(goals.get(id, {}))
		for brain in brains[id]:
			brain.set("objective", objective)
	var orders := CommandOrders.of(director.battle)
	if orders:
		orders.apply_to_brains(brains)      # a commander's orders come before the mode's plan (CommandOrders)


## net id of each AI-played combatant -> the brains that move it ([InfantryBot] / [AIPilot] / both when a bot pilots).
func make_brains() -> Dictionary:
	var out := {}
	for h in director.battle.vehicles.values():
		if not is_instance_valid(h) or h.has_meta(DEFENDER_META):
			continue
		var list := []
		for c in h.get_children():
			if c is InfantryBot or (c is AIPilot and c.is_physics_processing()):
				list.append(c)
		var soldier := h as Infantry
		if soldier and soldier.stowed and soldier.seat != null and soldier.seat.seat == VehicleOccupancy.PILOT_SEAT:
			var driver := soldier.seat.vehicle.get_node_or_null("BotDriver")
			if driver is AIPilot:
				list.append(driver)
		if not list.is_empty() and (h is Infantry or director.is_combatant(h)):
			out[h.net_id] = list
	return out


## The brain's form of a GameModeAI goal: the point plus the node to shoot ({} for no goal).
func make_objective(goal: Dictionary) -> Dictionary:
	if goal.is_empty():
		return {}
	var out := {"point": goal.point, "urgent": goal.urgent, "radius": goal.radius, "hold": goal.hold}
	var hunt: Node = director.battle.vehicles.get(int(goal.get("hunt", 0)))
	var target: Node = hunt if is_instance_valid(hunt) else director.make_objective_node(int(goal.get("attack_object", 0)))
	if target != null:
		out["target"] = target
	return out
