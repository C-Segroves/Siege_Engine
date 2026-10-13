class_name ES1SquadSpawner
extends RefCounted
## Spawns an Earthsiege campaign's wingmen (MissionRuntime): the original replaces MSN group 0 with
## the career squad from player.mec (mission.md section 2), so the squad comes from the battle config
## "squad" (SquadRoster: garage Hercs with their loadouts, condition and pilots) and starts in the
## player squad's slots behind the player, following him in formation.

## Original group order code the wingmen get (7 / 8 = patrol: with a leader they keep formation).
const WINGMAN_ORDER := 8
const PLAYER_TEAM := 0
const PLAYER_GROUP := 0

var rt: MissionRuntime


func _init(runtime: MissionRuntime) -> void:
	rt = runtime


## Spawns every wingman of the config's squad; returns them.
func spawn_squad() -> Array:
	var battle: Battle = rt.battle
	var squad: Array = battle.config.get("squad", [])
	var first_slot := (battle.config.get("roster", {}) as Dictionary).size()
	var leader_id: int = battle.player.net_id if battle.player else 0
	var units := []
	for k in squad.size():
		var w: Dictionary = squad[k]
		var info := {"skill": float(w.get("skill", 0.5)), "group": PLAYER_GROUP, "order": WINGMAN_ORDER, "path": [],
			"leader": leader_id, "formation_slot": first_slot + k, "garage": w.get("garage", {})}
		var unit: Herc = battle.spawn_ai(str(w.vehicle), PLAYER_TEAM, rt.player_spawn(first_slot + k), w.get("loadout", []),
			str(w.get("name", "")), info)
		if unit:
			units.append(unit)
	return units
