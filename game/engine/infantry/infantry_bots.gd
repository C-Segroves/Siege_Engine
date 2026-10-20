class_name InfantryBots
extends Node
## The match's AI soldiers (config "infantry_bots", the match setup's "Infantry bots" row; child "InfantryBots"
## of the Battle; docs/formats/tribes_infantry.md section 7). The host spawns them in Tribes armour like the
## players' soldiers and gives each an InfantryBot brain; every peer sees them through the usual soldier
## snapshots, occupancy and gear messages (host-authoritative). A bot has a bot id (BOT_ID_BASE - n) where a
## player has a peer id: the OccupancyDirector seats it, the stations serve it, the gear director throws for it.
## When a bot takes a vehicle's pilot seat the vehicle gets the existing AI pilot (AIPilot, or FlyerAI for a
## flyer) until the bot leaves it.
## Teams: skirmish / co-op alternate the enemy (team 1) and the player's squad (team 0), enemy first; versus
## with teams deals them round the config's "team_count" teams; free-for-all puts every bot on a team of its own.

const CONFIG_KEY := "infantry_bots"
const MAX_BOTS := 16
const BOT_ID_BASE := -1000
const PLAYER_TEAM := 0
const ENEMY_TEAM := 1
const FREE_FOR_ALL_TEAM_BASE := 200
## Every third bot wears medium armour (the others light: they can pilot every vehicle).
const MEDIUM_EVERY := 3
## Bots start this far apart round their spawn point (metres).
const SPAWN_SPREAD := 6.0
const BOT_SKILL := 0.5
const META_BRAIN := "bot_vehicle_brain"
const META_AI := "ai"

var battle: Battle
var _claims := {}        # vehicle net id -> bot id heading for it
var _next_index := 0     # bot ids are handed out once per match


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "InfantryBots"


func _ready() -> void:
	battle.occupancy.seats_changed.connect(_on_seats_changed)


static func is_bot(id: int) -> bool:
	return id <= BOT_ID_BASE


static func make_bot_id(index: int) -> int:
	return BOT_ID_BASE - index


## The number of bots `config` asks for.
static func make_count(config: Dictionary) -> int:
	return clampi(int(config.get(CONFIG_KEY, 0)), 0, MAX_BOTS)


## Config / lobby-settings key: {"bot:<i>" | "ai:<i>": team} the host picked for computer-controlled members.
const MEMBER_TEAMS_KEY := "member_teams"


## Team of bot `index` in a match with `config`.
static func make_team(config: Dictionary, index: int) -> int:
	var mode := str(config.get("mode", "skirmish"))
	if mode == "vs" and not bool(config.get("teams", false)):
		return FREE_FOR_ALL_TEAM_BASE + index
	if mode == "vs":
		var count := maxi(int(config.get("team_count", 2)), 2)
		var picked := int((config.get(MEMBER_TEAMS_KEY, {}) as Dictionary).get("bot:%d" % index, -1))
		return picked if picked >= 0 and picked < count else index % count
	return ENEMY_TEAM if index % 2 == 0 else PLAYER_TEAM


# ------------------------------------------------------------------ host: spawning

## Host: spawns the config's bots on every peer, in `pack`'s armour.
func spawn_all(pack: String) -> void:
	for i in make_count(battle.config):
		if not BotBudget.admits(battle, BotBudget.Priority.MATCH):
			return   # the server's bot cap (BotBudget)
		spawn_bot(make_bot_spec(pack, i), BOT_SKILL)


## Host: spawns the bot soldier of `spec` (make_bot_spec, or a mode's own) on every peer with its brain; null when the
## server's bot cap refuses it (BotBudget).
func spawn_bot(spec: Dictionary, skill: float) -> InfantryBot:
	if not BotBudget.admits(battle, make_budget_priority(spec)):
		return null
	LoadKeepAlive.pump()
	battle.send_spawn(spec)
	var s := battle.vehicles.get(int(spec.net_id)) as Infantry
	if s == null:
		return null
	var brain := InfantryBot.make(s, int(spec.owner), skill)
	s.add_child(brain)
	return brain


## The bot cap's priority of the soldier `spec`: a faction soldier (extraction garrison, squad, response) by its distance
## to the nearest human, a mission's soldier critical, the match's own bot a match bot.
func make_budget_priority(spec: Dictionary) -> int:
	if spec.has("faction"):
		return BotBudget.make_distance_priority(battle, (spec.xf as Transform3D).origin)
	return BotBudget.Priority.CRITICAL if battle.mission != null else BotBudget.Priority.MATCH


## A fresh bot id (never one handed out before in this match).
func allocate_bot_id() -> int:
	_next_index += 1
	return make_bot_id(_next_index - 1)


## The spawn spec of bot `index`: light armour (medium every third), the armour's spawn loadout.
func make_bot_spec(pack: String, index: int) -> Dictionary:
	var team := make_team(battle.config, index)
	var id := allocate_bot_id()
	var spec := battle.infantry.make_soldier_spec(id, team, "Bot %d" % (index + 1), _make_spawn(team, index))
	var size := "MEDIUM" if index % MEDIUM_EVERY == MEDIUM_EVERY - 1 else InfantryCatalog.LIGHT
	var armor_id := "%s:%s" % [pack, size]
	if not InfantryCatalog.armor(armor_id).is_empty():
		spec.armor = armor_id
		spec.vehicle = armor_id
		spec.loadout = InfantryCatalog.armor(armor_id).get("default_loadout", [])
	spec["bot"] = true
	return spec


func _make_spawn(team: int, index: int) -> Transform3D:
	var placed := []
	for h in battle.vehicles.values():
		if is_instance_valid(h):
			placed.append({"pos": (h as Herc).global_position, "team": (h as Herc).team})
	var xf := BattleSpawner.make_spawn_choice(battle.spawner.spawn_points, placed, team)
	var jitter := Vector3(cos(index * 2.4), 0.0, sin(index * 2.4)) * SPAWN_SPREAD
	return Transform3D(xf.basis, battle.infantry.make_on_ground(xf.origin + jitter))


# ------------------------------------------------------------------ host: vehicles

## Bot `bot_id` is heading for `vehicle` (other bots leave it alone).
func apply_claim(vehicle: Herc, bot_id: int) -> void:
	_claims[vehicle.net_id] = bot_id


func apply_release(bot_id: int) -> void:
	for k in _claims.keys():
		if _claims[k] == bot_id:
			_claims.erase(k)


## True when another bot than `bot_id` is heading for `vehicle`.
func is_claimed_by_other(vehicle: Herc, bot_id: int) -> bool:
	return _claims.has(vehicle.net_id) and _claims[vehicle.net_id] != bot_id


## A seat changed: a vehicle with a bot pilot gets its AI pilot, one without loses it (host).
func _on_seats_changed(vehicle: Herc) -> void:
	if not multiplayer.is_server() or not is_instance_valid(vehicle):
		return
	var pilot := VehicleOccupancy.of(vehicle).pilot()
	if is_bot(pilot):
		apply_release(pilot)
		_attach_brain(vehicle)
	elif vehicle.has_meta(META_BRAIN):
		_detach_brain(vehicle)


func _attach_brain(vehicle: Herc) -> void:
	vehicle.set_meta(META_BRAIN, true)
	vehicle.set_meta(META_AI, true)
	if vehicle is Flyer:
		(vehicle as Flyer).start_ai()
		return
	var brain := vehicle.get_node_or_null("BotDriver") as AIPilot
	if brain == null:
		brain = AIPilot.new()
		brain.name = "BotDriver"
		brain.herc = vehicle
		brain.skill = BOT_SKILL
		brain.order = AIPilot.Order.SEARCH
		vehicle.add_child(brain)
	brain.set_physics_process(true)


func _detach_brain(vehicle: Herc) -> void:
	vehicle.remove_meta(META_BRAIN)
	if vehicle.has_meta(META_AI):
		vehicle.remove_meta(META_AI)
	if vehicle is Flyer:
		(vehicle as Flyer).ai = null
	var brain := vehicle.get_node_or_null("BotDriver")
	if brain:
		brain.set_physics_process(false)


## Bots alive now (tests, HUD).
func make_bot_soldiers() -> Array:
	return battle.vehicles.values().filter(func(h) -> bool:
		return is_instance_valid(h) and h is Infantry and is_bot((h as Infantry).get_meta("bot_id", 0)))
