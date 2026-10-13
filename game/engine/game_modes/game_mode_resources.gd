class_name GameModeResources
extends Node
## Every peer: a switch's group (its tower's turrets, stations, generators, sensors) belongs to the team that holds
## the switch (Tribes 1 TowerSwitch::onCollision sets the group's team; Tribes 2 claimFlipflopResources). Applied
## from the replicated switch state whenever a holder changes: H's TribesBase objects and the map stations
## (TribesStations records) at the group's positions take the holder's team. Child "Resources" of
## GameModeDirector.

const GROUP_REACH := 1.5
const STATIONS_NODE := "Stations"

var director: GameModeDirector
var _applied := {}     # switch id -> team applied


func _init(p_director: GameModeDirector) -> void:
	director = p_director
	name = "Resources"


func _physics_process(_delta: float) -> void:
	for o in director.rules.objects_of(ModeObject.KIND_SWITCH):
		if o.group.is_empty() or int(_applied.get(o.id, ModeObject.NEUTRAL - 1)) == o.owner_team:
			continue
		_applied[o.id] = o.owner_team
		if o.owner_team >= 0:
			apply_team(o.group, o.owner_team)


## Every base object and station at one of `positions` joins `team`.
func apply_team(positions: Array, team: int) -> void:
	for node in make_group_nodes_of(director.battle, positions):
		node.set("team", team)
	var stations := director.battle.get_node_or_null(STATIONS_NODE)
	if stations != null and stations.get("stations") is Array:
		for s in stations.stations:
			if _is_in_group((s.xf as Transform3D).origin, positions):
				s.team = team


## The TribesBase objects of `battle` standing at `positions`.
static func make_group_nodes_of(battle: Node, positions: Array) -> Array:
	var out := []
	var base := battle.get_node_or_null(GameModeDirector.TRIBES_BASE_NODE)
	if base == null or not (base.get("objects") is Array):
		return out
	for obj in base.objects:
		if is_instance_valid(obj) and _is_in_group((obj as Node3D).global_position, positions):
			out.append(obj)
	return out


static func _is_in_group(p: Vector3, positions: Array) -> bool:
	for q in positions:
		if Vector3(float(q[0]), float(q[1]), float(q[2])).distance_to(p) <= GROUP_REACH:
			return true
	return false
