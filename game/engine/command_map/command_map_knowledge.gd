class_name CommandMapKnowledge
extends RefCounted
## What the command map may show the viewer (docs/COMMAND_MAP.md section 6.1):
##   combatants  friends always; enemies (and neutrals) only while his radar shows them now (RadarContacts.is_on_scope:
##               the Tribes sensor net, else his radar's range; hidden units and a lost sensor link never);
##   structures  his side's always; Tribes base objects of every team (the originals' command maps drew the enemy's
##               generators, turrets, sensors and stations: Tribes 1 Interface M_*_red, Tribes 2 cmdIcon on every
##               StaticShape) except an enemy's deployed ones, which only the sensor net would show; any other building
##               only when the mission makes it known: the target he has locked, or a mission target (Earthsiege 1 the
##               squad's order target, MSN group 0; Earthsiege 2 the squad's current order target and every
##               objective's target);
##   nav points  the mission's own (group "nav_points": the briefed and script-enabled markers only).


## True when `viewer`'s map shows combatant `unit`.
static func is_unit_known(viewer: Node, unit: Node) -> bool:
	if TeamRelations.is_allied(int(viewer.get("team")), int(unit.get("team"))):
		return true
	return RadarContacts.is_on_scope(viewer, unit)


## True when `viewer`'s map shows structure `s` (`mission_known`: make_mission_targets).
static func is_structure_known(viewer: Node, s: Node, mission_known: Array) -> bool:
	if s.get("team") != null and TeamRelations.is_allied(int(viewer.get("team")), int(s.get("team"))):
		return true
	if s is TribesBaseObject:
		return not (s as TribesBaseObject).self_powered
	return s == viewer.get("target") or mission_known.has(s)


## The buildings and units the battle's mission names as its targets (Earthsiege 1 / 2; none elsewhere).
static func make_mission_targets(battle: Node) -> Array:
	var mission = battle.get("mission")
	if not (mission is MissionRuntime):
		return []
	var rt := mission as MissionRuntime
	var out := []
	if rt.win_rules:
		out += rt.target_nodes(rt.win_rules.squad_target())
	if rt is MissionRuntimeES2:
		var es2 := rt as MissionRuntimeES2
		var order = es2.orders.current_order(0) if es2.orders else null
		if order is Dictionary:
			out += rt.target_nodes(order.get("target"))
		if es2.rules:
			for ob in es2.rules.objectives:
				out += rt.target_nodes(ob.def.get("target"))
	return out
