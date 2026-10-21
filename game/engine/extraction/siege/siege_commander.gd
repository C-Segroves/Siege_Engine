class_name SiegeCommander
extends RefCounted
## The Cybrids' orders (host): every retarget_s each living soldier and Herc of the siege gets the nearest prey as its
## objective (a faction site or a player on foot; players count player_bias times their distance, so a lone player is
## hunted from afar). A unit that meets enemies on the way fights them (the brains' own rule) and goes on after.

const ARRIVE_M := 40.0

var spawner: SiegeSpawner


func _init(p_spawner: SiegeSpawner) -> void:
	spawner = p_spawner


## The prey as [{pos, weight}]: weight 1 for a site, player_bias for a player.
func make_prey() -> Array:
	var bias := float(CybridRules.section("waves").get("player_bias", 0.7))
	var out := []
	var director := spawner.director
	if director.site_spawner != null:
		for s in director.site_spawner.sites:
			out.append({"pos": s.pos, "weight": 1.0})
	for peer in director.make_raid_peers():
		var soldier := director.battle.occupancy.soldier_of(int(peer))
		if soldier != null and soldier.alive and not soldier.stowed:
			out.append({"pos": soldier.global_position, "weight": bias})
	return out


## The prey point nearest to `from` by weighted distance; Vector3.INF with no prey.
static func make_nearest(prey: Array, from: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for p in prey:
		var d := from.distance_to(p.pos) * float(p.weight)
		if d < best_d:
			best_d = d
			best = p.pos
	return best


## Gives every living unit its objective and drops the dead from the roster.
func apply_retarget() -> void:
	var prey := make_prey()
	spawner.units = spawner.units.filter(func(u: Dictionary) -> bool: return is_instance_valid(u.unit) and (u.unit as Herc).alive)
	for u in spawner.units:
		var goal := make_nearest(prey, (u.unit as Herc).global_position)
		if goal != Vector3.INF:
			_apply_goal(u, goal)


func _apply_goal(u: Dictionary, goal: Vector3) -> void:
	var objective := {"point": goal, "urgent": false, "radius": ARRIVE_M, "hold": false}
	if u.brain is InfantryBot:
		(u.brain as InfantryBot).objective = objective
	elif u.brain is AIPilot:
		(u.brain as AIPilot).order = AIPilot.Order.SEARCH
		(u.brain as AIPilot).objective = objective
