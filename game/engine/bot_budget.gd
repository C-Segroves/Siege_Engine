class_name BotBudget
extends RefCounted
## The server's bot cap (setting "max_bots", 0 = no cap): every spawner of AI soldiers and AI vehicles asks `admits`
## before it spawns, so the total of live AI units stays under one number (docs/SERVER_DEPLOY.md, docs/
## DEDICATED_SERVER_SCALING.md section 8.5.3). The cap has reserves, so a distant garrison cannot use up the room a
## nearby fight or a mission needs:
##   CRITICAL  mission units: never refused (a mission cannot run without its units), but they count as live
##   MATCH     the match's own bots and a game mode's defenders: up to the cap
##   NEAR      a garrison or squad within near_m of a human: up to NEAR_SHARE of the cap
##   DISTANT   a garrison far from every human: up to DISTANT_SHARE of the cap

enum Priority { CRITICAL, MATCH, NEAR, DISTANT }

const CONFIG_KEY := "max_bots"
const NEAR_SHARE := 0.9
const DISTANT_SHARE := 0.7
## A spawn within this flat distance of a human is NEAR (m).
const NEAR_M := 250.0
const META_AI := "ai"


## The cap in force for `battle`: its config's "max_bots", else the host's settings; 0 = none.
static func make_cap(battle: Node) -> int:
	var config: Dictionary = battle.get("config") if battle.get("config") is Dictionary else {}
	return maxi(int(config.get(CONFIG_KEY, Net.settings.get(CONFIG_KEY, 0))), 0)


## True when a unit of `priority` may spawn now (always without a cap, and for CRITICAL).
static func admits(battle: Node, priority: int) -> bool:
	var cap := make_cap(battle)
	if cap <= 0 or priority == Priority.CRITICAL:
		return true
	return count_live(battle) < make_limit(cap, priority)


## How many live AI units a spawn of `priority` may find under a cap of `cap` and still be admitted.
static func make_limit(cap: int, priority: int) -> int:
	match priority:
		Priority.NEAR:
			return ceili(cap * NEAR_SHARE)
		Priority.DISTANT:
			return ceili(cap * DISTANT_SHARE)
	return cap


## Live AI soldiers plus AI vehicles of the battle.
static func count_live(battle: Node) -> int:
	var n := 0
	for v in battle.vehicles.values():
		if is_instance_valid(v) and is_ai_unit(v) and v.get("alive") != false:
			n += 1
	return n


static func is_ai_unit(unit: Node) -> bool:
	return unit.has_meta(META_AI) or unit.has_meta("bot_id") or InfantryBots.is_bot(int(unit.get("owner_peer")))


## NEAR when `at` is within NEAR_M of a human (or no human is in the match yet: a lone host's setup), else DISTANT.
static func make_distance_priority(battle: Node, at: Vector3) -> int:
	var humans := 0
	for v in battle.vehicles.values():
		if not is_instance_valid(v) or is_ai_unit(v) or v.get("alive") == false:
			continue
		humans += 1
		if Vector2(v.global_position.x - at.x, v.global_position.z - at.z).length() <= NEAR_M:
			return Priority.NEAR
	return Priority.NEAR if humans == 0 else Priority.DISTANT
